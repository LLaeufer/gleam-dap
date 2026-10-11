# Open questions

Decisions taken while implementing [PLAN.md](../PLAN.md) without asking.
**Every choice described here is already built.** Each file says where the
question came up, what was chosen, the other options with their trade-offs,
why, and what to change to go another way.

| File | Question | Chosen |
| --- | --- | --- |
| [01-fixture-location.md](01-fixture-location.md) | Where do the fixture projects live? | `fixtures/` at the top level |
| [02-dependencies.md](02-dependencies.md) | Use `gleam_json`, `gleam_otp` and `glance`? | None of them |
| [03-custom-type-labels.md](03-custom-type-labels.md) | Where do constructor and field names come from? | The `.hrl` record headers Gleam generates |
| [04-shadowed-variables.md](04-shadowed-variables.md) | How to show shadowed variables and compiler temporaries? | Latest binding in "Locals", everything in "Raw bindings" |
| [05-debug-console-language.md](05-debug-console-language.md) | What language does the debug console speak? | Gleam, with Erlang as the fallback |
| [06-stepping.md](06-stepping.md) | What exactly do step over and step out do in Gleam code? | Temporary breakpoints plus continue, so breakpoints inside calls stop |
| [07-stack-trace-mode.md](07-stack-trace-mode.md) | Which stack trace mode by default? | `all` |
| [08-exception-breakpoints.md](08-exception-breakpoints.md) | When to stop on crashes? | Gleam errors by default, all crashes opt-in |
| [09-packaging.md](09-packaging.md) | How to keep the adapter's stdlib apart from the program's? | Rename the adapter's dependencies when packaging |
| [10-uninterpreted-breakpoints.md](10-uninterpreted-breakpoints.md) | Breakpoints in modules that aren't interpreted? | Interpret them on demand, unless excluded or used by the adapter |
| [11-debug-break.md](11-debug-break.md) | How to ship and implement `debug.break()`? | A path-dependency package; breakpoint plus finish |
| [12-attach.md](12-attach.md) | How does attach connect and detach? | Distributed Erlang, `int:ni`, uninterpret on disconnect |
| [13-attach-through-launch.md](13-attach-through-launch.md) | How do IntelliJ users attach? | A `launch` with a `node` attaches |
| [14-vscode-extension.md](14-vscode-extension.md) | What does the VS Code extension contain and do? | Bundled adapter, started with `erl` directly |
| [15-test-target.md](15-test-target.md) | How does `target: "test"` run tests? | EUnit on every `*_test` module |
| [16-continue-and-pause.md](16-continue-and-pause.md) | Does continue resume one process or all? | All, unless the editor asks for one |
| [17-value-rendering.md](17-value-rendering.md) | How do dicts, functions, pids and long values look? | Gleam-style, with limits; large values paged |
| [18-ci.md](18-ci.md) | What does CI run? | OTP 27 and 28 on Linux and Windows, tests twice, the extension; only on request |
| [19-scope-cuts.md](19-scope-cuts.md) | What was left out? | Version checks without build (`args` and Windows came later) |
| [20-lsp4ij-template.md](20-lsp4ij-template.md) | Ship an importable LSP4IJ template? | Yes, untested in IntelliJ |
| [21-paging.md](21-paging.md) | How are values with more than 100 items shown? | DAP paging, and `[0..99]` groups for clients that don't page |
| [22-program-args.md](22-program-args.md) | How does the program get its `args`? | A second adapter VM started with them, relayed to |
| [23-gleam-evaluator.md](23-gleam-evaluator.md) | How is the Gleam expression evaluator built? | A Gleam front end in Erlang, translating to `erl_eval` forms |
| [24-attach-conditions.md](24-attach-conditions.md) | How do conditions and stepping work when attached? | A generated module on the node calls back to the adapter |
| [25-windows.md](25-windows.md) | What does Windows support consist of? | A `.cmd` launcher, path normalisation, a CI job; untested by hand |
