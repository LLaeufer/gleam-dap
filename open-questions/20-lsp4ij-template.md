# Ship an importable LSP4IJ template?

**Already built:** `editors/intellij/gleam-dap` is an LSP4IJ DAP template
folder: `template.json` (server name, the command, the `*.gleam` file
mapping), `launch.json`, `launch.test.json`, `launch.attach.json` and a
`README.md` that LSP4IJ shows behind its help icon. The README tells users
to import it with "Import from custom template..." and to change the
command to their `bin/gleam-dap`.

## Where and when it came up

Step 4 of PLAN.md: "Exported as a template in `editors/intellij/` if LSP4IJ
supports importing one." It came up when writing the IntelliJ docs. The
first version guessed the format; it was then checked against LSP4IJ's
source (`DAPTemplateManager.createDapTemplate`, `DAPTemplateDeserializer`
and the bundled templates such as `go-delve` and `julia`) and corrected: the
command goes in `launch.default`, and configurations are picked up from
files whose names start with `launch.` or `attach.`.

## What I chose

Ship the template, verified against LSP4IJ's loader but not run in a real
IntelliJ (no IntelliJ in the sandbox). All configurations use LSP4IJ's
Launch mode, including attach; see
[13-attach-through-launch.md](13-attach-through-launch.md).

## Options

### A. Importable template plus README steps (chosen)

- One import fills in the command, the file mapping and three ready
  configurations.
- If LSP4IJ changes its template format, the import may fail; the README's
  manual steps still work.
- The command can't be relative to the template, so users edit one path.

### B. README steps only

- Nothing to keep in sync with LSP4IJ.
- More clicking for the user, and more room for mistakes in the JSON.

### C. An IntelliJ plugin that bundles LSP4IJ settings

- Fully automatic, like the VS Code extension.
- A Gradle/Kotlin project to build and maintain for one config; far beyond
  the plan.

## Why

The plan asks for the template if LSP4IJ supports importing one, and it
does.

## How to change it

Delete the folder and keep the README section, or adjust the files. Trying
it in IntelliJ with LSP4IJ is the main open item for this editor.
