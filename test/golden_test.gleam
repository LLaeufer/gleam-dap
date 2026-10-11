//// Golden files for what the line mapping relies on: each fixture module's
//// source file and the lines `int` can stop on, per function. A Gleam
//// release that changes its generated code shows up here as a diff.
////
//// Regenerate with `GLEAM_DAP_UPDATE_GOLDEN=1 gleam test`.

import dap_client
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleam_dap/launch
import gleam_dap/project

@external(erlang, "test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Nil

@external(erlang, "test_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "gleam_dap_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

pub fn breakable_lines_test() {
  let dir = project.absname(dap_client.fixture())
  let assert Ok(config) = launch.decode_config(dict_new(), dir)
  let assert Ok(_) = launch.build(config)
  let index = project.build_index(dir, "sample")
  let text =
    project.project_modules(index)
    |> list.map(fn(module) {
      let functions =
        module.functions
        |> list.sort(fn(a, b) { int.compare(a.start, b.start) })
        |> list.map(fn(f) {
          "  "
          <> f.name
          <> "/"
          <> int.to_string(f.arity)
          <> " lines "
          <> int.to_string(f.start)
          <> "-"
          <> int.to_string(f.end)
          <> ": "
          <> join_ints(f.breakable)
          <> case f.lines_with_fun {
            [] -> ""
            lines -> " (fn on " <> join_ints(lines) <> ")"
          }
        })
      string.join(
        [
          module.module <> " " <> string.replace(module.source, dir <> "/", ""),
          ..functions
        ],
        "\n",
      )
    })
    |> string.join("\n")
  let golden = dap_client.project_root() <> "/test/golden/sample.txt"
  case get_env("GLEAM_DAP_UPDATE_GOLDEN") {
    Ok(_) -> write_file(golden, text <> "\n")
    Error(Nil) -> {
      let assert Ok(expected) = read_file(golden)
      assert text <> "\n" == expected
    }
  }
  assert dict.size(index.labels) == 2
}

fn join_ints(values: List(Int)) -> String {
  values |> list.map(int.to_string) |> string.join(" ")
}

@external(erlang, "maps", "new")
fn dict_new() -> a
