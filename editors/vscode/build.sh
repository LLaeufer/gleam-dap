#!/bin/sh
# Builds gleam-dap.vsix with the adapter bundled inside it.
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
(cd "$ROOT" && escript scripts/package.escript editors/vscode/adapter)
npx --yes @vscode/vsce@3.2.2 package --no-dependencies --allow-missing-repository -o gleam-dap.vsix
