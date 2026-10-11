# What does the VS Code extension contain and do?

**Already built:** `editors/vscode` builds `gleam-dap.vsix` (with
`sh editors/vscode/build.sh`), which bundles the packaged adapter. The
extension starts it as `erl -noinput -pa <extension>/adapter/ebin -eval
gleam_dap:main()`, unless `gleamDap.adapterPath` points at another
launcher. It registers the `gleam` debug type with launch and attach
snippets, enables breakpoints in `.gleam` files, and lets F5 debug the
workspace without a `launch.json`.

## Where and when it came up

Step 4 of PLAN.md: "A minimal extension ... that registers a `gleam` debug
type, provides a default `launch.json` snippet and starts the adapter via
`DebugAdapterExecutable`. Installed from a locally built `.vsix`." The open
details were where the adapter comes from, how it is started, and whether
the extension should declare the Gleam language.

## What I chose

- **Bundle the adapter** in the `.vsix`, with a setting to use another one.
- **Start `erl` directly** rather than the bundled `bin/gleam-dap` script:
  VS Code doesn't keep the executable bit when it unpacks an extension, so
  the script wouldn't run.
- **Declare the `gleam` language id** for `.gleam` files, so breakpoints can
  be set even without the official Gleam extension. VS Code merges language
  declarations, so this coexists with the Gleam extension.
- **Publisher `local`, version 0.1.0**, not published anywhere.
- **Build the extension on OTP 27 in CI**, so the bundled BEAM files load on
  every supported OTP version.

## Options

### Adapter location

- **Bundled (chosen):** install one file and it works; the adapter and
  extension versions always match. The `.vsix` must be rebuilt to update
  the adapter.
- **Only a path setting:** smaller extension, but every user has to build
  the adapter and configure a path first.

### Starting it

- **`erl` from the PATH (chosen):** works from an unpacked extension; uses
  the same Erlang the user's project uses.
- **A Node wrapper or chmod on activation:** more moving parts for the same
  result.

### Language id

- **Declare it (chosen):** breakpoints work with or without the Gleam
  extension.
- **Rely on the Gleam extension:** nothing duplicated, but without it the
  gutter doesn't accept breakpoints in `.gleam` files.

## Why

These choices make "build the `.vsix`, install it, press F5" the whole
setup, which is the plan's done-criterion for this step. The extension was
tried in code-server 4.96.4 (VS Code 1.96.4): breakpoint, step over and
variables work (see `docs/images/vscode.png`).

## How to change it

`editors/vscode/extension.js` (how the adapter starts) and
`editors/vscode/package.json` (language, settings, snippets).
