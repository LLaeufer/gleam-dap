#!/bin/sh
# Fills build/packages from the packages' GitHub repositories, for
# environments that can't reach the Hex package registry (such as some
# cloud sandboxes). With build/packages and manifest.toml in place, `gleam
# build` doesn't need the network. Normal setups don't need this script.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fetch() {
  # name version repository
  dir="$2"
  dest="$dir/build/packages/$1"
  if [ ! -d "$dest" ]; then
    mkdir -p "$dir/build/packages"
    git clone -q --depth 1 --branch "v$3" "https://github.com/$4" "$dest"
    rm -rf "$dest/.git"
  fi
}
for dir in "$ROOT" "$ROOT/fixtures/with_deps"; do
  fetch gleam_stdlib "$dir" 1.0.5 gleam-lang/stdlib
done
fetch gleam_erlang "$ROOT" 1.3.0 gleam-lang/erlang
fetch gleeunit "$ROOT" 1.11.0 lpil/gleeunit
cat > "$ROOT/build/packages/packages.toml" <<TOML
[packages]
gleam_stdlib = "1.0.5"
gleam_erlang = "1.3.0"
gleeunit = "1.11.0"
TOML
cat > "$ROOT/fixtures/with_deps/build/packages/packages.toml" <<TOML
[packages]
gleam_stdlib = "1.0.5"
TOML
echo "Dependencies are in build/packages."
