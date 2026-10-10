# Porting ElixirLS's debugger features to gleam-dap

ElixirLS's debug adapter is the most complete DAP debugger built on Erlang's
`int`. We are writing our own adapter in Gleam, so this document goes through
each ElixirLS feature: how it works there, what changes for Gleam, and when we
build it.

The survey is based on ElixirLS `master` at commit `68df44b` (16 August
2026), `apps/debug_adapter/lib/debug_adapter/`, with `int` behaviour checked
against OTP's `debugger` 5.3.1.2. Line numbers refer to `server.ex` unless
another file is named.

## Milestones

Features are grouped into the milestones of [PLAN.md](../PLAN.md):

- **M2 (core adapter):** enough to debug a Gleam program end to end.
- **M3 (feels like Gleam):** Gleam names, values, stack frames and errors.
- **M5 (advanced, new):** the rest of ElixirLS's feature set, after the
  editor setup in M4.

| Feature | ElixirLS | gleam-dap | Milestone |
| --- | --- | --- | --- |
| Handshake (`initialize`, `launch`, `configurationDone`) | yes | port, with Gleam build instead of Mix | M2 |
| Line breakpoints | yes, but no line validation | port and validate lines | M2 |
| Threads and thread events | yes | port | M2 |
| Continue, step in/over/out | yes | port, fix tail-call stepping | M2 |
| Stack trace | yes | port, Gleam names | M2 / M3 |
| Scopes and variables | yes | port, Gleam names and values | M2 / M3 |
| Output capture | yes | port | M2 |
| Terminate, disconnect, exit events | yes | port | M2 |
| Pause | yes, but doesn't really suspend | do it properly | M3 |
| Stop on Gleam errors | no | new | M3 |
| Function breakpoints | yes | port, Gleam syntax | M5 |
| Conditional breakpoints, hit counts, logpoints | yes | port, Erlang expressions first | M5 |
| Evaluate (debug console, watch, hover) | yes, in Elixir | Erlang expressions first | M5 |
| Completions in the console | yes, Elixir only | variable and module names | M5 |
| Attach to a running node | yes | port | M5 |
| Terminate single threads | yes | port | M5 |
| Cancel requests | yes | port | M5 |
| Breakpoint from code (`dbg`) | yes, via `Kernel.dbg` | small FFI function | M5 |
| Test integration and coverage | yes, ExUnit | gleeunit, later if at all | not planned |

## M2: core adapter

### Handshake

**ElixirLS** (lines 518-540, 924-1002, 1314-1326):

1. `initialize` stores the client's capabilities and replies with its own. Any
   other request before it is rejected.
2. `launch` does all the heavy work in a spawned process while the server
   waits: change directory, set environment, compile, interpret every module.
   When that finishes it sends the `initialized` event, then the launch
   response.
3. The client sets breakpoints. They verify straight away because modules are
   already interpreted.
4. `configurationDone` turns on `int:auto_attach` and only then starts the
   program.

**gleam-dap:** same order. The launch work becomes:

1. Check `gleam --version` ≥ 1.19 and OTP ≥ 27 (see
   [line-mapping.md](line-mapping.md)).
2. `gleam build --target erlang` in `projectDir`, failing the launch with the
   compiler's output on error.
3. Add `build/dev/erlang/*/ebin` to the code path and build the module ↔ file
   index.
4. Interpret the modules selected by the launch options (below).
5. On `configurationDone`, spawn `module:main()` (or the function the launch
   config names) under the captured group leader.

**Launch options**, based on ElixirLS's and adjusted for Gleam:

| Option | Default | Meaning |
| --- | --- | --- |
| `projectDir` | workspace folder | Gleam project root. |
| `module` / `function` | project name / `main` | Entry point, e.g. `app/cli` and `main`. |
| `args` | `[]` | Passed as command-line arguments (`argv`). |
| `env` | `{}` | Environment variables set before the program starts. |
| `target` | `dev` | `dev` builds or `test`, which runs `gleeunit` as the entry point. |
| `interpretDependencies` | `false` | Also interpret dependencies. ElixirLS interprets everything by default, which its README warns is slow. |
| `interpretModules` | `[]` | Extra module globs to interpret, e.g. `gleam/list`. Real globs, unlike ElixirLS, whose "globs" are regexes. |
| `excludeModules` | `[]` | Module globs never to interpret. Anchored, unlike ElixirLS's substring match. |
| `stackTraceMode` | `all` | `int:stack_trace/1`: `all`, `no_tail` or `false`. `all` keeps frames from tail calls, which helps a lot in Gleam. |
| `noDebug` | `false` | Run without interpreting anything. |

**Interpreting:**

- Use `int:i({Module, GleamPath, BeamPath, BeamBinary})`, because Gleam 1.19
  BEAM files have no `source` in their compile info and `int:i(Module)`
  can't find the file.
- Skip modules `int` can't interpret, sticky (OTP) modules, and every module
  the adapter itself uses while a process is paused. ElixirLS learned this the
  hard way: interpreting the code that formats values deadlocks as soon as it
  hits a breakpoint (ElixirLS issue #903). For us that means the adapter's own
  modules plus `gleam_stdlib`, `gleam_erlang`, `gleam_otp` and `gleam_json`
  unless the user explicitly asks for them.
- Interpret modules in parallel, which ElixirLS doesn't (lines 2849-2856).
- Cache each module's `module_info` when interpreting it. Calling
  `module_info` on an interpreted module while a process is paused can
  deadlock (ElixirLS issue #940).

### Line breakpoints

**ElixirLS** (lines 1113-1161, 2750-2847):

- Maps the file to modules, interprets them if needed, and calls
  `int:break/2`. Removed breakpoints get `int:delete_break/2`.
- Reports every breakpoint as verified, even on blank lines, where it never
  stops.

**gleam-dap:**

- File to module through the module index: `src/app/user.gleam` → `app@user`.
- Validate and move breakpoints to the nearest line with code, as described
  in [line-mapping.md](line-mapping.md), and support the
  `breakpointLocations` request.
- `.erl` FFI files in `src/` work too: the module is the file name.

### Threads

**ElixirLS** (lines 1328-1345, 2958-3096, `thread_registry.ex`):

- A two-way map between thread ids and pids, with ids that are never reused.
- In launch mode every local process counts as a thread, the adapter's own
  included.
- Names: registered name and OTP 27 process label, else the initial call.
- Polls every 3 seconds and sends `thread` started/exited events.

**gleam-dap:**

- Only list processes that matter: interpreted processes from
  `int:snapshot/0`, plus processes started by the program (descendants of
  the entry process, found through `$ancestors` and the process tree). Leave
  the adapter's processes out.
- Same naming, same polling and events.

### Detecting stops

**ElixirLS** (lines 72-78, 632-669):

- `int:auto_attach([break], {Server, breakpoint_reached, [Name]})` makes `int`
  spawn a process on every stop (breakpoint, or the end of a step), which
  just casts to the server.
- It never calls `int:attached/1`, so the meta process stays unattached and
  `auto_attach` keeps firing.
- On each stop it reads the whole stack once and sends `stopped`.

**gleam-dap:** copy this. Our experiments used `int:attached/1`, which also
works but means running an attach process per debugged process for nothing.

### Continue and stepping

**ElixirLS** (lines 1677-1773, 1834-1879):

- `continue`, `next`, `stepIn` and `stepOut` map to `int:continue/1`,
  `int:next/1`, `int:step/1` and `int:finish/1`.
- Each is wrapped in a try/catch that falls back to `int:continue/1`, because
  `int` can crash on internal pattern matches and would otherwise leave the
  session stuck.
- Unless the client asked for single-thread stepping, resuming one process
  resumes all other paused processes too.
- Calls into non-interpreted code are stepped over automatically.

**gleam-dap:** copy all of it, and fix stepping over tail calls, which
otherwise stops inside the called function. See "Stepping through generated
code" in [line-mapping.md](line-mapping.md).

### Stack trace

**ElixirLS** (lines 1393-1455, `stacktrace.ex`):

- Gets the meta process with `dbg_iserver:safe_call({get_meta, Pid})`, then
  `int:meta(Meta, backtrace, all)`, `bindings`, `stack_frame` and `messages`.
- These calls run in a throwaway process with a 5 second timeout, because
  `int:meta` waits forever if the meta process doesn't answer.
- The top frame's line comes from `int:snapshot/0`.
- Only interpreted frames appear.

**gleam-dap:**

- Same calls and the same timeout, but outside the main session process, so a
  slow stack read doesn't block other requests. ElixirLS does it inside its
  main GenServer and can stall for 5 seconds.
- Gleam names and file paths (M3, see below).

### Scopes and variables

**ElixirLS** (lines 1457-1611, `variables.ex`, `variable_registry.ex`,
`binding.ex`):

- Scopes: demangled variables, raw "versioned" variables, process info,
  arguments and the mailbox.
- Children by value type: maps by key, lists and tuples by index, functions
  through `erlang:fun_info/1`, pids through `process_info/1`.
- Values rendered with Elixir's `inspect`, with no size limit.
- Variable ids live until the process resumes. Requests run in their own
  cancellable processes.

**gleam-dap:**

- M2 ships the same scopes with raw Erlang names and Erlang-formatted values,
  with a size limit (`io_lib:format("~0tP", [Term, Depth])`).
- Gleam names and values follow in M3.

### Output capture

**ElixirLS** (`output.ex`, `wire_protocol.ex`, `output_device.ex`):

- Starts two small I/O servers for stdout and stderr and re-registers them as
  `user` and `standard_error`. The real devices move to `raw_user` and
  `raw_standard_error`.
- Sets every existing process's group leader to the new `user`.
- The DAP stream reads and writes the raw devices. Program output becomes
  `output` events with category `stdout` or `stderr`.

**gleam-dap:** same approach, in a small Erlang FFI module. Program reads
from stdin are not supported, as in ElixirLS, because stdin carries DAP.

### Terminate, disconnect and exit

**ElixirLS** (lines 456-503, 673-706):

- When the program's process exits: `terminated`, then `exited` with code 0
  for a normal exit and 1 otherwise.
- `disconnect` replies, waits 200 ms and halts the VM, which also stops the
  program.

**gleam-dap:** the same, plus DAP's `terminate` request (ask the program to
stop by killing its process tree, then halt), which ElixirLS doesn't support.

## M3: feels like Gleam

### Gleam names and values

- **Variables:** Gleam's `x` is `X` in Erlang, `my_var` is `My_var`, and
  shadowed variables become `X@1`, `X@2`. Show the latest version under the
  Gleam name, and keep a "raw" scope with all versions, like ElixirLS's
  "versioned variables". Hide compiler temporaries (`_pipe`, `_use0`,
  `_record`, ...).
- **Values:** format the way Gleam's `string.inspect` does: `Person(name:
  "Ada", age: 2)`, `[1, 2]`, `Some(1)`, `Ok(Nil)`, `<<1, 2>>`. Constructor
  names and field labels come from the record header files Gleam generates
  in `build/dev/erlang/<pkg>/include/` or from parsing the module source.
- **Children:** custom types expand into labelled fields, lists by index,
  dicts by key.

### Stack frames

- Name frames `app/user.greet` instead of `app@user:greet/1`, and anonymous
  functions as "anonymous function in `greet`".
- File paths from the module index.

### Pause that really pauses

**ElixirLS** (lines 1382-1391) implements pause with `int:attach/2`, which
only spawns a callback. The process keeps running and the adapter reports a
snapshot of its stack as "stopped".

**gleam-dap:** send `int:meta(Meta, stop)`, which makes the interpreted
process stop at its next expression, where `auto_attach` reports the stop
normally. Non-interpreted processes can't be paused; the response says so.

### Stop on Gleam errors (new)

ElixirLS has no exception breakpoints because `int` doesn't support them.
Gleam errors are easier: `panic`, `todo` and failed `let assert` raise a map
with `gleam_error`, `message`, `file` and `line`.

- Offer an exception filter "Gleam errors" (on by default) and "All crashes".
- Use `int:auto_attach([exit], ...)`, which fires when an interpreted process
  exits, and report a `stopped` event with reason `exception` and the error
  message. We checked this with a failing `let assert`: after the exit, the
  failing function's variables are still readable, but the backtrace is gone
  (`{boom, undefined, undefined}`). The stack frame for the error comes from
  the error map's `module`, `function` and `line` instead.
- Stopping *before* the crash with the full stack isn't straightforward with
  `int`, because breakpoints are per line and the failing branch of a
  `let assert` shares its line with the success branch. This is an open
  question for later.
- Fill in DAP's `exceptionInfo` request from the error map.

## M5: advanced features

### Function breakpoints

**ElixirLS** (lines 1174-1312): parses `Mod.fun/2`, calls `int:break_in/3`,
and compares `int:all_breaks/1` before and after to learn which lines it
covered (`break_in` sets a breakpoint on the first line of every clause).

**gleam-dap:** the same, with Gleam syntax: `app/user.greet` (any arity) or
`app/user.greet/1`. Private functions work too, since `break_in` works on any
interpreted function.

### Conditional breakpoints, hit counts and logpoints

**ElixirLS** (lines 2882-2926, `breakpoint_condition.ex`):

- `int:test_at_break(Module, Line, {M, F})` only takes a module and function,
  called with the bindings. So ElixirLS compiles 100 functions
  `check_0` ... `check_99` and hands out one per conditional breakpoint.
- Each check looks up its condition, evaluates it with the bindings, counts
  hits (break when hits ≥ the hit condition), and for logpoints prints the
  interpolated message and returns `false` so the process doesn't stop.
- Checks run inside the interpreter, so they must be quick and must never
  call into anything that could be paused.

**gleam-dap:**

- Generate the check module at runtime with `compile:forms/2`, adding slots
  as needed instead of a fixed 100.
- Conditions and logpoint expressions are Erlang expressions over the raw
  bindings at first, evaluated with `erl_eval`, with Gleam variable names
  mapped to their Erlang names (`x` → latest `X@N`). A Gleam expression
  syntax can come later (see evaluate).

### Evaluate

**ElixirLS** (lines 1613-1675, 1966-2070):

- `Code.eval_string` with the frame's bindings, in a helper process on the
  adapter, not in the paused process. No timeout, only cancel.
- Results get a variable reference so they can be expanded.

**gleam-dap**, in increasing difficulty:

1. Look up a variable or a field path (`user.name`, `list.0`). This covers
   most watch and hover uses and needs no evaluator.
2. Erlang expressions with `erl_eval` over the bindings, with a timeout.
3. Gleam expressions. Gleam has no evaluator; compiling a snippet needs the
   types of the variables in scope. Possible later through a scratch module
   compiled with `gleam`, but not planned.

Evaluate in the paused process with `int:meta(Meta, eval, ...)` when the
expression needs `self()` or the process dictionary.

### Completions

ElixirLS uses its Elixir completion engine. For us: variable names in scope,
module names, and a module's public functions after `module.`.

### Attach to a running node

**ElixirLS** (lines 1004-1074, 2359-2541):

- Connects to the node with `Node.connect`, loads the `debugger` application
  there, and interprets modules on all nodes with `int:ni/1`.
- Name and cookie come from environment variables, not the launch config.
- Conditions don't work in attach mode because the check module doesn't exist
  on the remote node.
- On disconnect it removes all breakpoints and un-interprets everything with
  `int:nn/1` so nothing stays interpreted on the remote node.

**gleam-dap:** the same, with `node` and `cookie` in the attach config, and
loading the generated check module on the remote node so conditions work
there too.

### Terminate threads and cancel

- `terminateThreads`: kill the processes (lines 1347-1368).
- `cancel`: stop an in-flight variables, evaluate or completions request
  (lines 855-922).

### Breakpoint from code

ElixirLS hooks `Kernel.dbg` so a `dbg()` call in code stops in the debugger,
which is the only way it can stop in non-interpreted code. A Gleam version
would be a tiny `debug.break()` function in an FFI module that calls the
adapter and waits until the user continues. Whether to hook Gleam's `echo`
as well is an open question.

## Not planned

- **Test integration and coverage:** ElixirLS reports ExUnit results and
  coverage through custom output events. gleeunit has no formatter hook, so
  this would need an eunit listener. Debugging tests works anyway with
  `target: test`.
- **Set variable, restart frame, step back:** ElixirLS doesn't support them
  either, and `int` doesn't make them practical.

## ElixirLS weaknesses we avoid

- Breakpoints on lines without code report as verified and never stop.
- Pause doesn't suspend the process.
- Module filters: excludes are unanchored regexes, include "globs" are
  regexes.
- No size limit when rendering values.
- Stack reads block the main server for up to 5 seconds.
- Evaluation has no timeout and runs outside the paused process.
- Modules are interpreted one at a time.
- Every process in the VM shows up as a thread, the adapter's included.
