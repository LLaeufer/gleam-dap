# Where do the fixture projects live?

**Already built:** the fixtures are in `fixtures/sample` and
`fixtures/with_deps`.

## Where and when it came up

Step 1 of PLAN.md asks for "a fixture Gleam project in `test/fixtures/`".
It came up when creating the first fixture: `gleam build` and `gleam test`
compile every `.gleam` file under `test/` as part of the gleam-dap project
itself.

## What I chose

A top-level `fixtures/` folder holding complete Gleam projects that the
tests build with their own `gleam build`.

## Options

### A. `fixtures/` at the top level (chosen)

- The fixtures are ordinary projects with their own `gleam.toml`, built
  exactly the way a user's project is.
- Nothing in them leaks into gleam-dap's own build or test run.
- Slight deviation from the plan's wording.

### B. `test/fixtures/` as the plan says

- Matches the plan.
- Gleam compiles `test/**/*.gleam` into the gleam-dap package, so the
  fixture's modules would become test modules of the adapter (wrong module
  names such as `fixtures@sample@src@sample`, duplicate `main`s, gleeunit
  trying to run them). Working around that needs renaming files to something
  other than `.gleam` and copying them before each test run.

### C. Generate fixtures into a temporary folder from strings in the tests

- Nothing on disk to keep in sync.
- The fixtures are much harder to read and to open in an editor for manual
  testing, and the line numbers the tests depend on are invisible.

## Why

Only A keeps the fixtures as real, openable Gleam projects without fighting
the build tool. The README's quick tour uses `fixtures/sample` directly.

## How to change it

Move the folders and update the paths in `test/dap_client.gleam`
(`fixture()`), `test/test_ffi.erl` (`start_target`), `test/golden_test.gleam`,
`scripts/spike.escript`, `scripts/offline-deps.sh`, and the `path` of the
`gleam_dap_debug` dependency in `fixtures/sample/gleam.toml`. Option B would
also need the renaming workaround described above.
