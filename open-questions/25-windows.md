# What does Windows support consist of?

**Already built (PR #5), but not tried on a Windows machine:** the parts
that were POSIX-only are replaced, and a Windows CI job runs the whole test
suite there (from source and against the packaged adapter). Like all CI it
only runs when started by hand, so until it has been run once, Windows
support is untested.

- `scripts/package.escript` also writes `bin/gleam-dap.cmd`, which runs
  `erl.exe -noinput -pa "%~dp0..\ebin" -eval "gleam_dap:main()" -extra %*`.
- Paths are normalised in one place (`absname` in `src/gleam_dap_ffi.erl`):
  forward slashes and a lowercase drive letter, so paths from the editor
  (`C:\proj\src\app.gleam`) match those from the compiler. Absolute source
  paths are detected with `filename:pathtype` instead of a leading `/`.
- `gleamPath` counts as a path when it contains `\` as well as `/`.
- The program-arguments relay (see [22-program-args.md](22-program-args.md))
  starts `erl.exe` from the running VM's own `bin` directory.
- `.gitattributes` keeps LF line endings in checkouts, because Windows
  runners convert to CRLF by default and the golden file is compared byte
  for byte.
- The test client runs a `.cmd` launcher through `cmd.exe /c`.
- Adapter node names now include the OS process id: two adapters started in
  the same second (as in the attach tests, and on any machine) could pick
  the same name and fail to start distribution. This showed up on Linux
  while adding the Windows job.

## Where and when it came up

Closing the gaps with ElixirLS, which supports Windows.
[19-scope-cuts.md](19-scope-cuts.md) had cut it from the first version.

## Options

### A. Port the POSIX-specific parts and test in CI (chosen)

- Small, contained changes; the transport stays the `{fd, 0, 1}` port,
  which OTP itself uses for `-noshell` stdio on Windows.
- Nothing was tried interactively on Windows. If the CI job fails on the
  stdio transport, the fallback is reading stdin through the `user` process
  with `-noshell` instead of `-noinput`.

### B. Leave Windows unsupported

- No risk of half-working support, but the gap stays.

## Why

A covers everything known to be POSIX-specific, and the CI job will show
what's left as soon as it runs.

## How to change it

The launcher is in `write_launchers` in `scripts/package.escript`; the CI
job is `windows` in `.github/workflows/ci.yml`.
