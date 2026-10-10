# Does continue resume one process or all of them?

**Already built:** `continue` resumes every paused process unless the
editor sends `singleThread: true`; the response says
`allThreadsContinued`. `pause` stops one process (the selected thread), and
step requests act on one process only.

## Where and when it came up

Step 2, implementing `continue` with several processes stopped at once
(the fixture's `spawn_worker`), and step 3 for `pause`.

## What I chose

Resume all on continue; pause and step one.

## Options

### A. Continue resumes all, unless `singleThread` (chosen)

- Matches what VS Code's Continue button suggests and what most debuggers
  do: after continuing, the program runs.
- With many processes stopped on the same breakpoint, one continue lets
  them all go, and the next hits stop again.

### B. Continue resumes only the selected process

- ElixirLS's behaviour; precise control over which process runs.
- Easy to leave other processes stopped forever without noticing, and the
  program looks hung.

### C. Pause stops every process

- Like pausing a whole program in other languages.
- BEAM programs can have thousands of processes; stopping all interpreted
  ones is slow and rarely what you want.

## Why

A gives the least surprising default, and DAP's `singleThread` flag keeps
B available to clients that support it.

## How to change it

`continue_request` and `pause` in `src/gleam_dap/session.gleam`.
