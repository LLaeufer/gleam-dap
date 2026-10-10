# Gleam Debugger (gleam-dap)

Debug Gleam programs on the Erlang VM from VS Code: breakpoints (with
conditions, hit counts and logpoints), stepping, Gleam-looking variables,
stops on `panic` and `let assert`, a debug console, and attaching to running
nodes.

Needs Gleam 1.19 or newer and Erlang/OTP 27 or newer (with the `debugger`
application) on the PATH. The debug adapter is bundled.

Open a Gleam project, set a breakpoint and press F5. Use "Debug: Add
Configuration..." for launch, test and attach configurations.

Settings:

- `gleamDap.adapterPath`: use another gleam-dap launcher instead of the
  bundled adapter.
- `gleamDap.logFile`: write the adapter's internal log to this file.

See the gleam-dap repository's README for all launch options and the known
limitations.
