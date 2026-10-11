# How do IntelliJ users attach?

**Already built:** a `launch` request that sets `node` attaches to that node
instead of starting the program. The LSP4IJ template's "Attach to Gleam
node" configuration is a launch configuration with `"request": "attach"`
and a `node`.

## Where and when it came up

Step 4, while checking the LSP4IJ template format against LSP4IJ's source
(`DAPTemplateManager`, `DAPCommandLineState`, `DAPClient`). In LSP4IJ, the
Attach debug mode doesn't start the adapter at all: it connects to an
adapter that is already listening on a TCP address and port. gleam-dap is an
stdio adapter started by the editor, so LSP4IJ's Attach mode can't reach it,
and LSP4IJ's Launch mode always sends a DAP `launch` request.

## What I chose

Interpret "launch with a `node`" as attach, in `session.prepare`.

## Options

### A. A launch with `node` attaches (chosen)

- Works with LSP4IJ's Launch mode, no new transport.
- VS Code users can keep using `"request": "attach"`; both paths are tested
  (`attach_test`, `attach_through_launch_test`).
- `launch` now has two meanings depending on one field, which is slightly
  surprising if you read the protocol log.

### B. Add a TCP server mode to the adapter

- Would fit LSP4IJ's Attach mode (and other socket-based clients).
- Someone has to start the adapter listening first, outside the IDE,
  before every session, and the adapter needs a socket transport next to
  stdio.

### C. Document attach as VS Code only

- No code.
- Leaves IntelliJ without attach, which PLAN.md asks for in both editors.

## Why

A gets attach working in IntelliJ with a three-line change and no extra
setup for the user.

## How to change it

Remove the `let mode = ...` block at the top of `session.prepare`
(`src/gleam_dap/session.gleam`) and the `launch.attach.json` file in
`editors/intellij/gleam-dap`.
