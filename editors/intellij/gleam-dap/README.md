gleam-dap debugs Gleam programs on the Erlang VM.

Set the command on the Server tab to the `bin/gleam-dap` launcher of a
packaged adapter (run `escript scripts/package.escript` in a checkout of
gleam-dap; the launcher ends up in `dist/gleam-dap/bin/gleam-dap`). The
adapter needs Erlang/OTP 27 or newer with the `debugger` application, and
Gleam 1.19 or newer on the PATH.

Keep the debug mode on **Launch**, also for attaching: LSP4IJ's Attach mode
connects to an adapter that is already listening on a socket, while gleam-dap
talks over stdin and stdout. A launch configuration with a `node` attaches to
that node instead of starting the program; pick the "Attach to Gleam node"
configuration and fill in the node name and cookie.
